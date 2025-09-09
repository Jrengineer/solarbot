from setuptools import setup

package_name = 'commcheck'

setup(
    name=package_name,
    version='0.0.1',
    packages=[package_name],
    data_files=[('share/' + package_name, ['package.xml'])],
    install_requires=['setuptools'],
    zip_safe=True,
    maintainer='kaan',
    maintainer_email='kaan@example.com',
    description='TCP heartbeat node for Flutter',
    license='MIT',
    entry_points={
        'console_scripts': [
            'commcheck = commcheck.commcheck:main',
        ],
    },
)
